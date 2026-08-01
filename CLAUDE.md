# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A DDEV addon that runs Claude Code CLI in a sandboxed container with network firewall (iptables, whitelist-based, default-deny). Enables `--dangerously-skip-permissions` with confidence by preventing prompt injection attacks from reaching arbitrary endpoints.

## Development Commands

```bash
# Install addon into a DDEV project (copies files to .ddev/)
ddev get florianriquelme/ddev-claude
ddev restart

# Rebuild claude container after Dockerfile changes
ddev restart

# Run Claude CLI with firewall
ddev claude
ddev claude --dangerously-skip-permissions
ddev claude --no-firewall        # Bypass firewall, logs domains accessed

# Manage whitelist
ddev claude:whitelist

# Debug firewall inside container
ddev exec -s claude iptables -L OUTPUT -n
ddev exec -s claude ipset list whitelist_ips

# Run tests
make test-unit           # Unit tests (44 tests, no DDEV needed)
make test-integration    # Integration tests (requires DDEV environment)
```

## Architecture

**Dedicated container approach:** The addon creates a separate `claude` container rather than modifying the web container. The web container needs unrestricted network for normal ops — Claude isolation shouldn't break the website.

**Key components:**

- `docker-compose.claude.yaml` — Service definition. Mounts project at `${DDEV_APPROOT}` (real host path, not `/var/www/html`). Masks `.env` and `.ddev/.env` with empty file. Requires NET_ADMIN + NET_RAW capabilities.
- `install.yaml` — DDEV addon manifest. Copies `claude/` dir and host commands into `.ddev/`. Declares a dependency on `Lullabot/ddev-gitleaks` (DDEV installs it automatically for non-blocking secret scanning of the container env and project `.env` files).
- `claude/Dockerfile.claude` — Builds on `debian:bookworm-slim`. Installs PHP, Node.js, Composer, iptables, ipset, jq, gum, Claude CLI. Creates symlink for ddev shim.
- `claude/bin/ddev` — ddev command shim. Auto-forwards runtime commands (php, composer, node, npm) to local runtime. Blocks lifecycle commands (start, restart, exec) with helpful hints.
- `claude/config/empty.env` — Empty file mounted over project `.env` and `.ddev/.env` to prevent Claude from accessing secrets.
- `claude/entrypoint.sh` — Firewall initialization. Rule order matters: loopback → DNS → established → whitelisted IPs → log → DROP.
- `claude/resolve-and-apply.sh` — Resolves domains to IPs via `dig` and adds to ipset.
- `claude/scripts/merge-whitelist.sh` — 3-tier config merge (default + global + per-project).
- `claude/scripts/watch-config.sh` — inotify watcher for hot reload on whitelist changes (2s debounce).
- `claude/scripts/reload-whitelist.sh` — Flushes ipset and re-resolves on config change.
- `commands/host/claude` — Host command: `ddev claude [args]`. Handles `--no-firewall` flag.
- `commands/host/claude-whitelist` — Host command: `ddev claude:whitelist`. Interactive domain selection via gum.

**Whitelist config hierarchy (merged with `jq`):**
1. Default: `claude/config/default-whitelist.json` (Claude API, GitHub, npm, Composer, CDNs)
2. Global: `~/.ddev/ddev-claude/whitelist.json`
3. Per-project: `.ddev/ddev-claude/whitelist.json`

Stack templates in `claude/config/stack-templates/` (laravel.json, npm.json).

## Coding Conventions

- **Language:** All scripts are Bash. Use `set -euo pipefail` in every script.
- **Logging:** `LOG_PREFIX="[ddev-claude]"` with `log()` and `error()` helper functions.
- **DDEV marker:** Files managed by DDEV start with `#ddev-generated` comment.
- **JSON whitelist format:** Simple arrays: `["domain1.com", "domain2.com"]`. Validated with `jq empty`.
- **Error handling:** Entrypoint uses `trap ... ERR` to fail closed if firewall setup fails.
- **Test naming:** Bats test files are numbered: `tests/XX-<component>.bats` (e.g., `01-firewall.bats`).

## File Coupling

When modifying these files, expect to update their counterparts in the same commit:

- `entrypoint.sh` ↔ `resolve-and-apply.sh` (firewall init and domain resolution)
- `docker-compose.claude.yaml` ↔ `install.yaml` (service definition and addon manifest)
- `claude/scripts/*.sh` ↔ `tests/*-<matching-component>.bats` (scripts and their tests)
- `Dockerfile.claude` ↔ `entrypoint.sh` or scripts (new packages need wiring)
- `commands/host/*` ↔ `claude/scripts/*` (host commands often pair with container scripts)
- Whitelist JSON configs ↔ corresponding whitelist `.bats` tests

## Project Planning

Planning artifacts live in `.planning/`:
- `PROJECT.md` — Core value, constraints, key decisions
- `REQUIREMENTS.md` — v1 requirements with traceability IDs (FIRE-*, CONF-*, UI-*, SAFE-*, DDEV-*, SKILL-*)
- `ROADMAP.md` — 4-phase roadmap. Phases 1-2 complete, 3-4 pending.
- `STATE.md` — Current position and accumulated context
- Phase plans in `phases/` subdirectories

## Current Status

Phases 1 (Firewall Foundation) and 2 (Configuration & Commands) are complete. The **env-isolation** feature is also complete, adding:
- Environment file masking (`.env` and `.ddev/.env` appear empty inside claude container)
- ddev command shim with smart forwarding (runtime commands work, lifecycle commands blocked)

**Test coverage:** 44 unit tests + 9 integration tests covering firewall, hooks, commands, env isolation, and ddev shim behavior.

Next up is Phase 3 (Safety Warnings & Documentation) which includes mount detection warnings and additional `.env` protection checks.
